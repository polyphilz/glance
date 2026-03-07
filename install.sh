#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"

# Ensure target directory exists
mkdir -p "$TARGET_DIR"

# Create symlink
ln -sf "$SCRIPT_DIR/bin/glance" "$TARGET_DIR/glance"

echo "Installed glance -> $TARGET_DIR/glance"
echo "Make sure $TARGET_DIR is on your PATH."
