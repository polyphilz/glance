#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BASH_BIN="$(command -v bash)"
DIRNAME_BIN="$(command -v dirname)"
GIT_BIN="$(command -v git)"

"$ROOT/bin/glance" --version >"$TMP_DIR/version.out"
grep -Fx -- "glance $VERSION" "$TMP_DIR/version.out" >/dev/null

"$ROOT/bin/glance" --help >"$TMP_DIR/help.out"
grep -Fx -- "glance - review git changes in a clean Neovim session" "$TMP_DIR/help.out" >/dev/null
grep -Fx -- "  glance --help" "$TMP_DIR/help.out" >/dev/null
grep -Fx -- "  glance init-config [--force]" "$TMP_DIR/help.out" >/dev/null
grep -Fx -- "  - nvim 0.11+ on PATH" "$TMP_DIR/help.out" >/dev/null

cd "$TMP_DIR"
if "$ROOT/bin/glance" >"$TMP_DIR/outside.out" 2>"$TMP_DIR/outside.err"; then
  echo "expected bin/glance to fail outside a git repo" >&2
  exit 1
fi

grep -F "glance: not a git repository" "$TMP_DIR/outside.err" >/dev/null

INIT_HOME="$TMP_DIR/init-home"
mkdir -p "$INIT_HOME"
env -u GLANCE_CONFIG -u XDG_CONFIG_HOME HOME="$INIT_HOME" "$ROOT/bin/glance" init-config >"$TMP_DIR/init-config.out" 2>"$TMP_DIR/init-config.err"
DEFAULT_CONFIG="$INIT_HOME/.config/glance/config.lua"
[ -f "$DEFAULT_CONFIG" ]
grep -F "glance: wrote starter config to $DEFAULT_CONFIG" "$TMP_DIR/init-config.err" >/dev/null
grep -Fx -- "    preset = 'seti_black'," "$DEFAULT_CONFIG" >/dev/null

if env -u GLANCE_CONFIG -u XDG_CONFIG_HOME HOME="$INIT_HOME" "$ROOT/bin/glance" init-config >"$TMP_DIR/init-config-second.out" 2>"$TMP_DIR/init-config-second.err"; then
  echo "expected init-config to fail when the config already exists" >&2
  exit 1
fi
grep -F "glance: config already exists at $DEFAULT_CONFIG" "$TMP_DIR/init-config-second.err" >/dev/null

CUSTOM_CONFIG="$TMP_DIR/custom/config.lua"
env -u XDG_CONFIG_HOME HOME="$INIT_HOME" GLANCE_CONFIG="$CUSTOM_CONFIG" "$ROOT/bin/glance" init-config --force >"$TMP_DIR/init-config-custom.out" 2>"$TMP_DIR/init-config-custom.err"
[ -f "$CUSTOM_CONFIG" ]
grep -F "glance: wrote starter config to $CUSTOM_CONFIG" "$TMP_DIR/init-config-custom.err" >/dev/null

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/clean-repo" "$TMP_DIR/dirty-repo"
cat >"$TMP_DIR/bin/nvim" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "NVIM v0.11.6"
  exit 0
fi

printf '%s\n' "$@" >"${GLANCE_CAPTURE:?}"
printf '%s\n' "${GLANCE_ROOT:-}" >"${GLANCE_ROOT_CAPTURE:?}"
exit 0
EOF
chmod +x "$TMP_DIR/bin/nvim"

mkdir -p "$TMP_DIR/git-only-bin" "$TMP_DIR/old-nvim-bin" "$TMP_DIR/no-git-bin"
ln -sf "$DIRNAME_BIN" "$TMP_DIR/git-only-bin/dirname"
ln -sf "$GIT_BIN" "$TMP_DIR/git-only-bin/git"
cat >"$TMP_DIR/old-nvim-bin/nvim" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "NVIM v0.10.4"
  exit 0
fi

echo "unexpected nvim launch" >&2
exit 1
EOF
chmod +x "$TMP_DIR/old-nvim-bin/nvim"
ln -sf "$DIRNAME_BIN" "$TMP_DIR/old-nvim-bin/dirname"
ln -sf "$GIT_BIN" "$TMP_DIR/old-nvim-bin/git"
ln -sf "$BASH_BIN" "$TMP_DIR/old-nvim-bin/bash"
ln -sf "$(command -v sed)" "$TMP_DIR/old-nvim-bin/sed"
ln -sf "$DIRNAME_BIN" "$TMP_DIR/no-git-bin/dirname"

SPACED_ROOT="$TMP_DIR/root with space"
mkdir -p "$SPACED_ROOT/bin"
cp "$ROOT/bin/glance" "$SPACED_ROOT/bin/glance"

git -C "$TMP_DIR/clean-repo" init >/dev/null 2>&1
git -C "$TMP_DIR/dirty-repo" init >/dev/null 2>&1
echo "pending" >"$TMP_DIR/dirty-repo/pending.txt"

(
  cd "$TMP_DIR/clean-repo"
  env PATH="$TMP_DIR/git-only-bin" "$BASH_BIN" "$ROOT/bin/glance" >"$TMP_DIR/clean-repo.out" 2>"$TMP_DIR/clean-repo.err"
)
grep -F "glance: no changes found" "$TMP_DIR/clean-repo.err" >/dev/null

(
  cd "$TMP_DIR/dirty-repo"
  if env PATH="$TMP_DIR/git-only-bin" "$BASH_BIN" "$ROOT/bin/glance" >"$TMP_DIR/missing-nvim.out" 2>"$TMP_DIR/missing-nvim.err"; then
    echo "expected bin/glance to fail when nvim is missing" >&2
    exit 1
  fi
)
grep -F "glance: nvim 0.11+ is required but was not found on PATH" "$TMP_DIR/missing-nvim.err" >/dev/null

(
  cd "$TMP_DIR/dirty-repo"
  if env PATH="$TMP_DIR/old-nvim-bin" "$BASH_BIN" "$ROOT/bin/glance" >"$TMP_DIR/old-nvim.out" 2>"$TMP_DIR/old-nvim.err"; then
    echo "expected bin/glance to fail for unsupported nvim versions" >&2
    exit 1
  fi
)
grep -F "glance: nvim 0.11+ is required, found 0.10.4" "$TMP_DIR/old-nvim.err" >/dev/null

(
  cd "$TMP_DIR/dirty-repo"
  if env PATH="$TMP_DIR/no-git-bin" "$BASH_BIN" "$ROOT/bin/glance" >"$TMP_DIR/missing-git.out" 2>"$TMP_DIR/missing-git.err"; then
    echo "expected bin/glance to fail when git is missing" >&2
    exit 1
  fi
)
grep -F "glance: git is required but was not found on PATH" "$TMP_DIR/missing-git.err" >/dev/null

if "$ROOT/bin/glance" nope >"$TMP_DIR/unknown.out" 2>"$TMP_DIR/unknown.err"; then
  echo "expected unknown commands to fail" >&2
  exit 1
fi
grep -F "glance: unknown command or option: nope (run 'glance --help')" "$TMP_DIR/unknown.err" >/dev/null

(
  cd "$TMP_DIR/dirty-repo"
  env \
    PATH="$TMP_DIR/bin:$PATH" \
    GLANCE_CAPTURE="$TMP_DIR/nvim.args" \
    GLANCE_ROOT_CAPTURE="$TMP_DIR/glance-root.txt" \
    "$SPACED_ROOT/bin/glance"
)

grep -Fx -- "--clean" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "-c" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "lua require('glance.bootstrap').run()" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "--cmd" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "lua vim.opt.runtimepath:append(vim.env.GLANCE_ROOT)" "$TMP_DIR/nvim.args" >/dev/null
grep -Fx -- "$SPACED_ROOT" "$TMP_DIR/glance-root.txt" >/dev/null
