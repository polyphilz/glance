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

ARCHIVE_STANDALONE="$TMP_DIR/standalone"
ARCHIVE_HOME="$TMP_DIR/archive-home"
ARCHIVE_PAYLOAD="$TMP_DIR/archive-payload"
ARCHIVE_FILE="$TMP_DIR/glance-main.tar.gz"

mkdir -p "$ARCHIVE_STANDALONE" "$ARCHIVE_HOME" "$ARCHIVE_PAYLOAD/glance-main/bin" "$ARCHIVE_PAYLOAD/glance-main/lua/glance" "$TMP_DIR/fake-bin"
cp "$ROOT/install.sh" "$ARCHIVE_STANDALONE/install.sh"
chmod +x "$ARCHIVE_STANDALONE/install.sh"
cp "$ROOT/bin/glance" "$ARCHIVE_PAYLOAD/glance-main/bin/glance"
cp "$ROOT/VERSION" "$ARCHIVE_PAYLOAD/glance-main/VERSION"
cp "$ROOT/lua/glance/init.lua" "$ARCHIVE_PAYLOAD/glance-main/lua/glance/init.lua"
tar -czf "$ARCHIVE_FILE" -C "$ARCHIVE_PAYLOAD" glance-main

cat >"$TMP_DIR/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cp "${GLANCE_TEST_ARCHIVE:?}" "${output:?}"
EOF
chmod +x "$TMP_DIR/fake-bin/curl"

HOME="$ARCHIVE_HOME" \
PATH="$TMP_DIR/fake-bin:/usr/bin:/bin" \
GLANCE_REF=main \
GLANCE_TEST_ARCHIVE="$ARCHIVE_FILE" \
"$ARCHIVE_STANDALONE/install.sh" >"$TMP_DIR/archive-install.out" 2>"$TMP_DIR/archive-install.err"

ARCHIVE_TARGET="$ARCHIVE_HOME/.local/bin/glance"
ARCHIVE_EXPECTED="$ARCHIVE_HOME/.local/share/glance/main/bin/glance"
if [ ! -L "$ARCHIVE_TARGET" ]; then
  echo "expected $ARCHIVE_TARGET to be a symlink" >&2
  exit 1
fi

ARCHIVE_ACTUAL="$(readlink "$ARCHIVE_TARGET")"
if [ "$ARCHIVE_ACTUAL" != "$ARCHIVE_EXPECTED" ]; then
  echo "expected $ARCHIVE_TARGET -> $ARCHIVE_EXPECTED, got $ARCHIVE_ACTUAL" >&2
  exit 1
fi

grep -F "Installing glance from main..." "$TMP_DIR/archive-install.out" >/dev/null
grep -F "Installed glance -> $ARCHIVE_TARGET" "$TMP_DIR/archive-install.out" >/dev/null

if grep -F "unbound variable" "$TMP_DIR/archive-install.err" >/dev/null; then
  echo "unexpected unbound variable error during archive install" >&2
  exit 1
fi

HOME="$ARCHIVE_HOME" "$ARCHIVE_TARGET" --version >"$TMP_DIR/archive-version.out"
grep -Fx -- "glance $VERSION" "$TMP_DIR/archive-version.out" >/dev/null
