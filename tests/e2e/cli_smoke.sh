#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$TMP_DIR"
if "$ROOT/bin/glance" >"$TMP_DIR/outside.out" 2>"$TMP_DIR/outside.err"; then
  echo "expected bin/glance to fail outside a git repo" >&2
  exit 1
fi

grep -F "glance: not a git repository" "$TMP_DIR/outside.err" >/dev/null

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/link" "$TMP_DIR/repo"
cat >"$TMP_DIR/bin/nvim" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${GLANCE_CAPTURE:?}"
exit 0
EOF
chmod +x "$TMP_DIR/bin/nvim"

ln -s "$ROOT/bin/glance" "$TMP_DIR/link/glance"

git -C "$TMP_DIR/repo" init >/dev/null 2>&1
(
  export PATH="$TMP_DIR/bin:$PATH"
  export GLANCE_CAPTURE="$TMP_DIR/nvim.args"
  cd "$TMP_DIR/repo"
  "$TMP_DIR/link/glance"
)

grep -Fx -- "--clean" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "-c" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "Glance" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "--cmd" "$TMP_DIR/nvim.args" >/dev/null
grep -F "set rtp+=$ROOT" "$TMP_DIR/nvim.args" >/dev/null
